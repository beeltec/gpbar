# Coding guideline index

Research date: 2026-09-20.

These guides cover the technologies selected in [the implementation plan](../plan.md).
They use primary documentation from Apple, Swift, Rust, library maintainers, and standards publishers.
Source links appear beside the rules they support.

The project now contains a development application and backend integration.
Use [live validation](../manual-validation.md) for observed results and remaining checks.
Build success does not establish runtime compatibility.

## Guide selection

| Guide | Coverage |
| --- | --- |
| [Swift and SwiftUI](swift-and-swiftui.md) | Swift API design, concurrency, Observation, SwiftUI, AppKit, menu bar lifetime, accessibility. |
| [Browser authentication](browser-authentication.md) | WKWebView, AuthenticationServices, NSWorkspace, SAML callbacks, browser cleanup, small HTML/JavaScript launch pages. |
| [Privileged helper and IPC](privileged-helper-and-ipc.md) | SMAppService, launchd, XPC identity checks, Foundation Process, pipes, JSON messages, session ownership. |
| [Rust and FFI](rust-and-ffi.md) | Rust modules, errors, Tokio cancellation, Serde, C ABI, bindgen, libopenconnect resource lifetime. |
| [VPN and networking](vpn-and-networking.md) | GlobalProtect, OpenProtect, OpenConnect, reqwest/rustls, XML, HIP, utun, routes, DNS, recovery. |
| [Security and storage](security-and-storage.md) | UserDefaults, Keychain, OSLog, Rust tracing, sensitive data, privacy manifests. |
| [Build and release](build-and-release.md) | Xcode, Cargo, shell scripts, dylibs, bundle layout, signing, Hardened Runtime, notarization, notices. |
| [Validation and workflow](validation-and-workflow.md) | Live verification, compiler checks, source evidence, Conventional Commits, Conventional Branches, comments. |

## How to apply the guidance

The imperative rules in these files are GPClient implementation requirements.
Citations explain the underlying API behavior or upstream recommendation.
They do not mean that each project-specific design is required by Apple or another maintainer.

Use the API documentation matching the pinned SDK, language mode, crate version, and target OS.
Links containing `latest` are discovery references, not permission to update dependencies.
Check API availability before copying examples into the macOS 26 codebase.
Keep the vendored Rust edition until a separate compatibility change requires migration.

The user's choices take precedence over generic style advice.
In particular, this project uses live validation and necessary comments only.
Some upstream guides recommend automated tests or comments on every declaration; those recommendations are not adopted here.

The user requested an in-app browser as the default.
External-browser authentication remains available because some identity providers or device policies may reject embedded login.
Document that tradeoff without claiming universal tenant compatibility.

Network Extension, SwiftData, a JavaScript application framework, and a full Swift VPN engine are outside the current scope.
Do not introduce those technologies merely because other VPN clients use them.

When adding a technology, add its primary references and project-specific rules to the relevant guide.
Update this index and [AGENTS.md](../../AGENTS.md) when the reading routes change.
