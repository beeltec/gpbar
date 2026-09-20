# Compatibility status

| Component or environment | Status |
| --- | --- |
| Apple Silicon, macOS 26.6.2 | Native settings, helper registration, embedded authentication, connection, cancellation, and normal disconnect observed. |
| macOS 26.0 | Deployment target set; oldest-version runtime check pending. |
| SAML-enabled provider portal | Authenticated tunnel connected. Gateway accepted HIP submission; individual posture-policy coverage remains unverified. |
| Another GlobalProtect portal | No approved second environment supplied. |
| In-app browser | Microsoft login, automatic callback capture, owned-window closure, and close-to-cancel observed. |
| Default browser | Brave Origin private login opened; cancellation passed. Authenticated callback completion and successful-login closure remain pending. |
| Specific browser | Installed-app picker observed. Callback-handler registration and live completion pending. |
| IPv4 | Tunnel connected. Requested public endpoint was unreachable while connected and answered after disconnect. Routes and DNS restored. |
| IPv6 | Route parsing and configuration present; live behavior unverified. |
| Developer ID / notarization | Credentials unavailable during implementation; release not produced. |

A portal requiring password-only login, direct Okta authentication, or client-certificate setup receives an unsupported-flow result.
The first release does not provide those authentication interfaces.
A successfully displayed login page does not prove that an organization's policy accepts this client.
