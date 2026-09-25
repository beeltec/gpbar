# GPBar agent instructions

## Read before changing files

Read [the README](README.md) for product scope, setup, and current limits.
Read the public guide relevant to your change:

| Area | Guide |
| --- | --- |
| Authentication, browser login, credentials, and certificates | [Authentication support](AUTHENTICATION.md) |
| macOS login SSO, login plug-in, installation, and recovery | [macOS login SSO](LOGIN-SSO.md) |
| Update behavior, signing, and local publishing | [Automatic updates](UPDATES.md) |
| Build inputs, distribution, and CI releases | [Tagged releases](RELEASE.md) |
| DNS selection, split DNS, and resolver recovery | [Split DNS](DNS.md) |
| Dependencies and licensing | [Third-party notices](THIRD-PARTY-NOTICES.md) |

Some local checkouts contain an ignored `docs/` folder with planning notes and detailed coding guidelines.
When available, read `docs/plan.md` and use `docs/guidelines/README.md` to select relevant guides before changing files.
Public contributors do not need these local files. Follow the rules below and the existing code style.
Changes across a process boundary require reviewing both sides.

## Product rules

- Build a general GlobalProtect client. Never hardcode a company portal.
- Save a valid entered address automatically and restore it across launches.
- Start the normal flow when the user clicks Connect.
- Default to in-app login. Preserve the user's default-browser or specific-browser choice.
- Capture `globalprotectcallback:` automatically and continue connection setup.
- Close owned authentication windows or tabs where the browser supports reliable cleanup.
- Do not confuse launching at macOS login with connecting after browser authentication.
- Preserve the process boundaries and supported-platform scope described in the README.

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
- Keep public behavior and support limits current in the README and relevant technical guides.
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
- The user's “usual workflow” applies only when explicitly invoked. Follow the steps supplied with that request.

## Writing

Use plain English and sentences shorter than 25 words.
Do not add marketing claims.
Add comments only when needed to explain contracts, safety requirements, or non-obvious decisions.
Follow ASD-STE100 for comments and keep them current.
