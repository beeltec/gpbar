# Validation, documentation, and Git guidelines

Research date: 2026-09-20. Scope: every project change.

## Project validation policy

Do not create automated tests, test targets, suites, or test harnesses.
Validate application behavior live on a Mac and through actual browser sessions.
Preserve existing upstream tests without deleting or expanding them.
Do not run automated test suites as a substitute for the user's live-validation requirement.

Compilation, static analysis, and document checks are allowed.
They do not establish authentication, route cleanup, accessibility, or signed-helper behavior.
SwiftUI previews are design aids, not runtime evidence.

For documentation-only changes, check consistency, Markdown links, and `git diff --check`.
Do not connect a VPN, change network settings, or install a daemon to validate prose.

## Build and static checks

After the corresponding project targets exist, use the narrow checks relevant to the change:

| Area | Check |
| --- | --- |
| Swift application and helper | Build the intended Xcode scheme with the declared deployment target and signing configuration. |
| Rust production crates | `cargo check --locked --workspace --lib --bins` from the vendored workspace. |
| Rust linting | `cargo clippy --locked --workspace --lib --bins` with the pinned toolchain and existing lint policy. |
| Rust formatting | Run the pinned formatter check; do not apply unrelated vendor-wide formatting changes. |
| Shell | Use the script's shell syntax check and ShellCheck where its dialect is supported. |
| Property lists | Use `plutil -lint` on changed property-list files. |
| Binary dependencies | Inspect shipped executables and dylibs with `otool -L`. |
| Final signature | `codesign --verify --deep --strict --verbose=2 /path/to/GPBar.app`. |
| Gatekeeper | `spctl --assess --type execute --verbose=2 /path/to/GPBar.app`. |
| Notarization ticket | `xcrun stapler validate /path/to/GPBar.app`. |

Paths in the table are examples; resolve actual artifacts before running checks.
Do not use `cargo test`, `swift test`, or `xcodebuild test` for this workflow.
Do not add `--all-targets` when the task only requires production binaries and libraries.
Cargo documents target selection, and Apple documents nested signature verification. [Cargo targets](https://doc.rust-lang.org/cargo/commands/cargo-build.html), [Signature verification](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

## Live application checks

Use the full scenario matrix in [the plan](../plan.md) and select cases affected by the change.
At minimum, validate the normal path and the relevant cancellation or failure path.

- UI: open the menu bar panel repeatedly, change focus, use keyboard navigation, and inspect accessibility.
- Settings: enter an address, restart, verify persistence, and try an invalid replacement.
- Authentication: use each supported browser mode, receive callbacks, cancel early, and verify owned-page cleanup.
- Helper: approve, decline, revoke approval, reconnect XPC, and reject unauthorized or wrong-user requests through controlled live checks.
- Tunnel: connect to an approved service, inspect DNS and routes, disconnect, and verify restoration.
- Recovery: exercise network loss, sleep/wake, process failure, and helper restart on a controlled Mac.
- Privacy: inspect sanitized output and exported diagnostics for accidental secrets and unnecessary personal data.
- Release: run the packaged artifact on the oldest supported macOS version and the current supported version.

Accessibility Inspector supports inspection of the running interface. [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)

Use approved accounts and endpoints for real networking checks.
Do not interrupt another VPN session or unrelated work to simulate failures.
Capture before/after route and resolver state without committing company-sensitive details.
If a necessary environment is unavailable, report the missing live check and its impact honestly.

## Evidence and documentation

Record build identity, OS version, backend revision, browser version, scenario, observed result, and any limitation.
Distinguish intended behavior from verified behavior.
Do not claim a browser supports automatic tab closure based only on successful callback delivery.
Do not claim a tunnel is ready based only on an interface appearing.

Keep source links next to claims when researching APIs.
Prefer primary documentation and inspect versions before adopting examples.
Update the plan when product behavior changes and the relevant guide when implementation rules change.
Do not add marketing claims to documents, UI text, release notes, or comments.

## Comments and plain language

Write short sentences in plain English, with fewer than 25 words each.
Add comments only for necessary contracts, safety reasoning, or non-obvious behavior.
Keep comments synchronized with the code.
Use ASD-STE100 as required by the user's instructions. [ASD-STE100](https://www.asd-ste100.org/)
Do not claim formal ASD-STE100 compliance from a readability check alone.

## Git workflow

Inspect the working tree before editing and preserve unrelated changes.
Commit each completed unit with a Conventional Commit message, such as `docs: add native client coding guidelines`.
Use clear types and optional scopes; mark actual breaking changes explicitly. [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)

Use Conventional Branch names such as `feat/native-macos-client` or `fix/callback-cancellation`, without AI prefixes.
Simple changes can be made on `main`.
Keep a unit of work on its branch; ask about merging before starting another unit on a new branch.
These branch rules combine the user's workflow with [Conventional Branch](https://conventionalbranch.org/).

Do not push, open a PR, merge, or publish merely because a local documentation edit is complete.
Follow the authorization in the active user request.

When the user invokes the “usual workflow”, follow their full sequence:

1. Create a Conventional Branch for the requested work.
2. Implement the work and validate it live on the relevant application, browser, or device.
3. Complete relevant build and static checks; retain the live-only policy above.
4. Run independent code-review axes using `codex review` in parallel and wait for every report.
5. Fix findings and repeat the review loop until no issues remain.
6. Create the PR or MR, squash-merge unless instructed otherwise, and clean up the completed local branch.

Do not invoke this extended workflow unless the user requests it.
