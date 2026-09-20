# GPBar agent instructions

## Read before changing files

Read [the implementation plan](docs/plan.md) for product behavior and scope.
Use [the guideline index](docs/guidelines/README.md) to select the guides relevant to your work.
Read each relevant guide before changing its area.
Changes across a process boundary require the guides for both sides.

| Area | Required guide |
| --- | --- |
| Swift, concurrency, SwiftUI, AppKit, accessibility | [Swift and SwiftUI](docs/guidelines/swift-and-swiftui.md) |
| WebKit, browser choice, SAML, callback handling, login HTML | [Browser authentication](docs/guidelines/browser-authentication.md) |
| ServiceManagement, launchd, XPC, process control, JSON protocol | [Privileged helper and IPC](docs/guidelines/privileged-helper-and-ipc.md) |
| Rust, Tokio, Serde, C bindings, libopenconnect integration | [Rust and FFI](docs/guidelines/rust-and-ffi.md) |
| GlobalProtect, OpenProtect, OpenConnect, TLS, XML, routes, DNS | [VPN and networking](docs/guidelines/vpn-and-networking.md) |
| Preferences, credentials, logs, privacy | [Security and storage](docs/guidelines/security-and-storage.md) |
| Xcode, Cargo, shell scripts, native dependencies, signing, distribution | [Build and release](docs/guidelines/build-and-release.md) |
| Every change: verification, documentation, Git | [Validation and workflow](docs/guidelines/validation-and-workflow.md) |

## Product rules

- Build a general GlobalProtect client. Never hardcode a company portal.
- Save a valid entered address automatically and restore it across launches.
- Start the normal flow when the user clicks Connect.
- Default to in-app login. Preserve the user's default-browser or specific-browser choice.
- Capture `globalprotectcallback:` automatically and continue connection setup.
- Close owned authentication windows or tabs where the browser supports reliable cleanup.
- Do not confuse launching at macOS login with connecting after browser authentication.
- Preserve the process boundaries and supported-platform scope in the plan.

## Engineering rules

- Favor correctness, clarity, and the simplest complete solution.
- Prefer existing OpenProtect and OpenConnect functionality over new implementations, including when reviewing previously added features.
- Before adding authentication code, inspect the pinned libraries and document any missing capability or incompatible behavior.
- Keep custom code limited to required platform integration, security controls, and verified upstream gaps.
- Apply YAGNI. Do not add frameworks, packages, or abstractions for possible future requirements.
- Share business rules, not merely similar-looking code. Small duplication can be clearer than the wrong abstraction.
- Follow the surrounding style. Keep changes to vendored code focused and traceable.
- Keep unsafe code, privileged operations, and protocol parsing behind small, explicit interfaces.
- Preserve unrelated work and avoid destructive actions outside the requested scope.
- Keep product requirements in the plan and implementation rules in the linked guides. Update both when a decision changes.
- Treat the guides as project decisions informed by sources, not automatic adoption of every upstream recommendation.
- Follow explicit user instructions when they differ from a guide. Record material changes in the relevant document.

## Validation and delivery

- Do not create automated tests, test targets, or test suites. Validate behavior live on macOS and in real browsers.
- Preserve existing upstream tests; do not delete or expand them to satisfy this rule.
- Use builds and static checks where relevant. Do not report them as live runtime validation.
- Do not install a helper or change live networking just to validate documentation.
- Commit completed units with Conventional Commits.
- Use Conventional Branch names without AI prefixes. Simple work may stay on `main`.
- Keep a unit of work on one branch. Ask about merging before starting a new unit on another branch.
- The user's “usual workflow” applies only when invoked; see the workflow guide.

## Writing

Use plain English and sentences shorter than 25 words.
Do not add marketing claims.
Add comments only when needed to explain contracts, safety requirements, or non-obvious decisions.
Follow ASD-STE100 for comments and keep them current.
