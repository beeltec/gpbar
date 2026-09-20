# Build, shell, packaging, and release guidelines

Research date: 2026-09-20. Scope: Xcode, Cargo, native dependencies, scripts, signing, and distribution.

## Reproducible build inputs

Pin the Xcode toolchain, supported Swift language mode, Rust toolchain, OpenConnect, route script, and native dependency versions.
Keep the deployment target consistent across Swift, Rust, and C libraries.
Keep `Cargo.lock` and record the features used by release builds.
Use `cargo build --locked` to prevent unnoticed dependency resolution changes. [Cargo build](https://doc.rust-lang.org/cargo/commands/cargo-build.html)

Keep Apple Silicon and macOS 14 as the planned baseline until the compatibility phase provides evidence for a change.
Check SDK availability for every introduced API.
Do not infer minimum-OS support from a successful build on the newest Mac.

Separate build dependencies from shipped runtime dependencies.
Users must not need Homebrew, Rust, Xcode, or the original reference folder.
Refuse a release build that selected OpenProtect's stub tunnel implementation.

## Xcode project and archive

Keep application and helper targets explicit, with shared configuration only where settings really match.
Check in required shared schemes and project settings; exclude personal Xcode state and generated output.
Model script inputs and outputs so incremental builds cannot reuse stale engine artifacts.
Do not disable script sandboxing globally merely to hide undeclared build dependencies.

Archive and export the application with the correct Developer ID configuration.
Check `SKIP_INSTALL` for embedded targets so the archive contains the intended application product.
Preserve bundle and framework symlinks when copying products; Apple recommends `ditto` for this purpose. [Distribution-signed macOS code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

## Native runtime bundle

- Include the helper and engine in appropriate executable locations inside the application bundle.
- Place non-system dylibs in `Contents/Frameworks` and include their transitive runtime dependencies.
- Use the exact header/library pair for generated FFI bindings.
- Rewrite install names and runpaths before signing.
- Inspect every shipped Mach-O image with `otool -L`, not just the top-level executable.
- Refuse unresolved Homebrew, workspace, temporary-build, or developer-home paths.
- Keep the route/DNS script and required HIP resources inside the sealed bundle.
- Verify script dependencies against the supported macOS installation, including differences between BSD and GNU utilities.
- Never download executable dependencies at first connection as a substitute for packaging them.

## Shell scripts

Use the shell declared by the shebang.
Prefer POSIX `sh` for simple portable packaging tasks; use Bash only when the script needs its features.
Do not assume modern Homebrew Bash exists on users' Macs.
Preserve the dialect of the vendored route script.

Quote variable expansions and use argument arrays or positional arguments when supported.
Unquoted expansion can perform word splitting and filename expansion. [ShellCheck SC2086](https://www.shellcheck.net/wiki/SC2086)

- Do not construct commands with `eval` or concatenate user input into shell source.
- Pass positional arguments as `"$@"`; do not turn them into one command string.
- Check critical exit statuses explicitly. `set -e` alone is not a complete failure policy.
- Use `pipefail` only in shells that support it.
- Create temporary directories securely and clean up only paths owned by that invocation.
- Validate destructive targets before removal. Never target a home or repository root.
- Install output atomically where possible and keep a failed build from replacing a working artifact.
- Handle spaces in application paths and resource names.
- Keep secrets out of `set -x`, logs, environment dumps, and command arguments.
- Run ShellCheck for supported script dialects, alongside the shell's syntax check.

## Signing and notarization

Sign nested libraries, executables, and helpers before sealing the outer application.
Use the proper identity for each artifact and preserve the entitlements required by its target.
Do not use `codesign --deep` as a substitute for an explicit signing order.
Using `--deep` for verification is a separate operation.

Enable Hardened Runtime and secure timestamps for distribution.
Exclude development `get-task-allow` from release signatures.
Do not disable library validation merely to load an unsigned bundled dependency.
These are documented notarization concerns. [Common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

Use Developer ID distribution, submit with `notarytool`, inspect the result, and staple the ticket.
Keep signing credentials outside the repository.
Notarization checks the submitted software; it does not prove VPN correctness or authorize helper operations. [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Distribution and updates

Verify the final packaged artifact on a clean supported Mac.
Check installation, quarantine/Gatekeeper behavior, helper approval, complete login, connection, disconnection, and removal.
Stop an active engine before replacing its runtime bundle.
Coordinate helper and protocol versions during upgrades and preserve user preferences.
Do not add automatic updates; they remain outside the first-release scope.

Preserve the supplied OpenProtect license notices and inventory the exact distributed dependency licenses.
OpenConnect publishes its license as LGPL 2.1. [OpenConnect licensing](https://www.infradead.org/openconnect/licence.html)
Review source availability, notices, and applicable redistribution requirements for the actual binary composition before shipping.
Do not infer that one dependency's license covers the whole bundle.

Use [the validation guide](validation-and-workflow.md) for check commands and evidence requirements.
