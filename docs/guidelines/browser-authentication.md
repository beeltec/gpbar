# Browser and authentication guidelines

Research date: 2026-09-20. Scope: WebKit, AuthenticationServices, browser selection, callbacks, and login launch pages.

## Required experience

Follow the login flow in [the plan](../plan.md).
One Connect action opens the saved browser choice, completes authentication, and continues tunnel setup automatically.
Default to the in-app browser and retain default-browser and specific-browser options.
Manual callback paste is a troubleshooting fallback, not the normal flow.

Use one user-process authentication coordinator for each active attempt.
It owns the browser, challenge ID, cancellation, callback handling, and page cleanup.
Keep portal authentication logic in the engine; Swift owns browser presentation and safe callback transport.

## In-app WebKit

Host `WKWebView` in SwiftUI through `NSViewRepresentable` on the macOS 14 baseline.
Use `WKNavigationDelegate` to intercept the callback before navigation.
Use `WKUIDelegate` for popup and new-window requests belonging to the login attempt.
Apple documents these responsibilities in [WKNavigationDelegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate) and [WKUIDelegate](https://developer.apple.com/documentation/webkit/wkuidelegate).

- Capture callback navigation once, cancel that navigation, and forward it through the active coordinator.
- Handle both normal redirects and links opening a new window.
- Complete each WebKit policy decision handler exactly once.
- Show the current login hostname and keep normal TLS trust evaluation enabled.
- Use an isolated, nonpersistent website data store for each attempt initially.
- Keep legitimate identity-provider JavaScript and form posts working.
- Do not inject password-reading scripts, alter login forms, or copy browser cookies into the application.
- Never grant remote pages a general-purpose native message bridge or privileged command interface.
- Close only owned login windows after the engine confirms authentication success.
- Treat user closure before completion as cancellation. A programmatic success close must not cancel tunnel setup.

Nonpersistent WebKit storage is an explicit API option. [WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent%28%29)

## External browser selection

Consider `ASWebAuthenticationSession` for browser-managed login and callback delivery.
On macOS, it uses a compatible default browser or falls back to Safari.
It is not an in-app WebKit view and does not select arbitrary browser applications.
Its callback routing belongs to the requesting session. [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)

Use only initializers available on the supported OS, with availability checks where necessary.
Keep the session object alive until completion or cancellation.
Verify actual GlobalProtect callback compatibility; do not assume an OAuth sample matches this protocol.

For a specific browser, persist its bundle identifier and resolve its installed application when connecting.
Use `NSWorkspace` to open the launch URL in that application.
If it is missing, offer browser selection rather than silently replacing the preference.
This API returns an application, not an authentication-tab reference. [NSWorkspace URL opening](https://developer.apple.com/documentation/appkit/nsworkspace/open%28_%3Awithapplicationat%3Aconfiguration%3Acompletionhandler%3A%29)

## Callback validation

- Accept a callback only for a live, waiting session and authentication challenge.
- Bound its length before parsing. Use the protocol limit defined with the engine.
- Validate the exact callback scheme and parse the existing GlobalProtect formats without treating the token as a normal HTTPS URL.
- Reject malformed encoding, empty required fields, conflicting duplicate fields, and already-consumed responses.
- Never log a raw callback, even when rejecting it.
- Invalidate the attempt on cancellation, timeout, portal change, or replacement by a new session.
- Do not accept cold-launch callbacks as permission to start a new connection.
- Use protocol-supported correlation where available; an internal challenge ID does not authenticate a supplied token.
- A JWT-shaped string is not a verified identity. Let the configured portal validate the credential through the existing protocol.

In ordinary external-browser mode, register native URL handling and verify handler ownership during setup.
Do not silently take the official client's scheme association.
Prefer in-app interception or managed-session callbacks when they avoid that conflict.

## Tenant compatibility and OAuth guidance

OAuth native-app guidance favors external user agents over embedded login.
That recommendation has security and shared-login benefits. [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252)

This project uses GlobalProtect/SAML and explicitly offers an in-app browser by user request.
Do not describe that choice as compliance with every OAuth recommendation or identity-provider policy.
Do not add PKCE parameters to a protocol that does not support them.
Validate the actual tenant, MFA, passkeys, and device-access policy.
Offer a fresh external-browser attempt if embedded login is rejected.

## Closing external authentication pages

Verify callback delivery and tab closure separately for each supported browser.
Use browser-managed cleanup or an adapter that owns a specific authentication tab or dedicated window.
If browser automation is needed, explain and request only its required macOS permission.
Never close the current tab by position, issue a global keyboard shortcut, or quit the browser.

JavaScript cannot reliably close every external tab; browser rules restrict script closure. [Window.close](https://developer.mozilla.org/en-US/docs/Web/API/Window/close)
Failure to close a tab must not stop an authenticated VPN connection.
Explain that the remaining tab can be closed manually and record the browser's capability gap.

## Loopback server and HTML

Keep any launch server on loopback with an unpredictable, short-lived path and bounded request handling.
Validate request paths and Host headers, disable caching, and close listeners on completion or cancellation.
Do not expose Tailscale listeners, public-IP lookups, or an unauthenticated HTTP token-submission endpoint in application mode.

Preserve SAML redirect and form-post semantics, including correctly encoded hidden fields.
Use a serializer or proper context-specific escaping when producing HTML or JavaScript.
Do not concatenate callback values or user-entered text into executable script or raw markup.
Do not load analytics or third-party assets from the login launch page.

Validate the complete browser flow using [live browser checks](validation-and-workflow.md).
