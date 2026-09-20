# Rust, Tokio, Serde, and C FFI guidelines

Research date: 2026-09-20. Scope: the vendored OpenProtect backend and its OpenConnect bindings.

## Preserve the existing architecture

Keep the supplied Rust workspace and its edition unless a specific implementation need requires a migration.
Use the existing crate boundaries for protocol, authentication, tunnel, route, DNS, and IPC responsibilities.
Avoid broad formatting or dependency changes inside vendored code.
Record modifications and their upstream baseline as described in [the plan](../plan.md).

Use concrete types, enums, and `Result` for protocol state and errors.
Keep recoverable input and network failures out of panic paths.
Use typed library errors and add safe context at application boundaries, following the existing project style.
Do not derive or emit `Debug` for secrets without explicit redaction.

Unsafe public functions need documented caller obligations.
Safety comments are necessary comments under this project's minimal-comment rule. [Rust API documentation guidance](https://rust-lang.github.io/api-guidelines/documentation.html)

## Tokio execution

Use async I/O for network requests and command handling.
Keep bounded blocking work out of async executor threads.
Keep the long-running OpenConnect loop on a dedicated owned thread, consistent with the existing backend.

Started `spawn_blocking` work cannot be aborted through its task handle.
Runtime shutdown timeouts stop waiting; they do not terminate that work.
Tokio recommends dedicated threads for long-lived blocking loops. [Tokio spawn_blocking](https://docs.rs/tokio/latest/tokio/task/fn.spawn_blocking.html)

- Use the tunnel library's cancellation handle to interrupt blocking tunnel operations.
- Make portal requests, browser waits, OTP waits, and reconnect backoff observe the session cancellation signal.
- Use bounded channels for commands and events.
- Do not hold a lock across `.await` or across a blocking library call.
- Keep one owner of reconnect policy; Swift must not start another retry loop.
- Retain join handles and observe task errors. Detached tasks must not survive a session accidentally.
- Ensure shutdown waits for required workers and closes their resources.

Tokio describes shutdown as detection, notification, and waiting for completion. [Graceful shutdown](https://tokio.rs/tokio/topics/shutdown)
Apply those stages to the whole engine, not just its main future.

## Serde and framed messages

Follow the protocol rules in [the helper guide](privileged-helper-and-ipc.md).
Use derived serialization with explicit tags and stable names.
Avoid untagged command enums where ambiguous input could match an unintended operation.
Serde documents the tradeoffs between tag representations. [Enum representations](https://serde.rs/enum-representations.html)

Limit bytes before deserialization and separately bound collections and strings.
Use integers for counters and explicitly documented units for durations.
Do not change field meanings while keeping the same protocol version.
Do not use tracing output as a machine-readable state contract.

## Safe C and libopenconnect boundaries

Keep raw FFI declarations inside `gp-openconnect-sys` and safe ownership wrappers inside `gp-tunnel`.
Generate bindings from the exact headers used to build the linked library.
Use a small C shim only where the ABI requires it, such as variadic callbacks.

Run bindgen from the existing build script with the correct target, include paths, and deployment settings.
Allowlist only the required functions, types, and constants; keep generated bindings out of manual edits.
Bindgen documents target-aware generation and symbol filtering. [Build-script integration](https://rust-lang.github.io/rust-bindgen/library-usage.html), [Allowlisting](https://rust-lang.github.io/rust-bindgen/allowlisting.html)

- Match ABI, integer widths, signedness, pointer types, and struct layouts exactly.
- Validate null pointers and lengths before making Rust slices or references.
- Keep callback contexts alive until the C library can no longer invoke them.
- Document whether C borrows, copies, or takes ownership of each pointer and string.
- Free memory with the allocator required by the API that created it.
- Prevent Rust panics from crossing a non-unwinding C ABI boundary.
- Do not mark handles `Send` or `Sync` without proving the underlying library contract.
- Keep `unsafe` blocks small and state their safety argument where it is not obvious.

These rules follow the ownership and ABI requirements described in [the Rustonomicon FFI guide](https://doc.rust-lang.org/nomicon/ffi.html).
Review the pinned OpenConnect public header for each function's actual contract; do not guess from another library's API.

For project-owned C shims, enable applicable Clang warnings and fix format-string, conversion, and lifetime issues.
Check allocation sizes, truncation, and library return values before passing data back to Rust.
Keep warnings scoped so they do not trigger unrelated rewrites of third-party code. [Clang diagnostics](https://clang.llvm.org/docs/UsersManual.html)

## Resource and error cleanup

Use owned Rust wrappers and `Drop` for normal resource release.
Also implement explicit asynchronous shutdown where worker coordination is required.
Destructors cannot provide recovery after forced process termination.
Keep the helper's network journal as the recovery mechanism for that case.

Check every C return code before publishing success.
Distinguish an accepted credential, a created interface, configured networking, and a usable session.
Make cleanup safe after partial setup and repeat requests.

## Static checks

Use the pinned rustfmt and Clippy versions on the changed production targets.
Address relevant warnings without broad lint suppressions or unrelated vendor rewrites.
Clippy supports target-specific checking and configured lint levels. [Clippy usage](https://rust-lang.github.io/rust-clippy/usage.html)

Do not add tests or expand upstream test suites.
Use the production build and [live validation](validation-and-workflow.md), including cancellation during blocking tunnel setup.
