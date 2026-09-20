# Privileged helper and IPC guidelines

Research date: 2026-09-20. Scope: ServiceManagement, launchd, XPC, Foundation Process, and the Swift/Rust message boundary.

## Service registration

Use `SMAppService` with an embedded launch daemon property list and a declared Mach service.
Keep helper resources in the app bundle and use the documented `BundleProgram` structure.
Treat registration, approval, service availability, and successful XPC negotiation as separate conditions.
Check status after the app returns from System Settings. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [Embedded helper structure](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)

Use `SMAppService.mainApp` separately for the optional launch-at-login setting.
Do not require Terminal commands for normal setup or connection.
Do not implement password collection, `sudo` wrappers, or a root GUI.

## Identity and authorization

Authenticate the application at the helper listener and authenticate the helper from the application.
Use code-signing requirements for the expected signing team and code identifier.
Apply the requirement before resuming each connection.
Apple exposes [listener requirements](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement%28_%3A%29) and [connection requirements](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement%28_%3A%29).

- Do not trust a PID, executable filename, supplied bundle identifier, or claimed user ID as authentication.
- Read user identity from the operating system's XPC connection metadata.
- Enforce session ownership separately from signature validation.
- Restrict first-release sessions to the active console user, following the plan's logout and switching policy.
- Do not assume another application signed by the same team may control this helper.
- Keep development signing rules explicit and out of production builds.
- Refuse incompatible application, helper, and engine protocol versions before accepting commands.

## Narrow privileged operations

Expose start, cancel, disconnect, snapshot, and bounded diagnostic operations only as required by the plan.
The helper must not provide arbitrary shell commands, arbitrary paths, or arbitrary environment variables.
Validate every message before it reaches a privileged operation.
UI validation improves feedback; helper validation protects the boundary.

Resolve bundled resources from trusted installation locations.
Check signatures, sealed resources, ownership, permissions, and symlink behavior before execution.
Close replacement races between validation and use; document the chosen launch strategy during the helper spike.
Do not load binaries, configuration, or libraries from the caller's writable search path.

## XPC and JSON contract

Use a small explicit XPC interface with versioned `Codable` data payloads and restricted accepted argument types.
Specify Serde tag names and Swift coding keys in the shared protocol document.
Serde supports explicit enum tags; choose one stable representation. [Serde enum representations](https://serde.rs/enum-representations.html)

- Bound input data before JSON decoding and enforce field-level length limits.
- Include protocol version, session ID, challenge ID when relevant, command ID, and event sequence number.
- Separate acknowledgement of a command from successful completion of its operation.
- Make cancellation and disconnect idempotent.
- Define whether compatible-version unknown fields are ignored; reject unknown commands and incompatible versions.
- Do not let generic unknown-field handling silently change a privileged operation's meaning.
- Retain the 256 KiB provisional frame ceiling from the plan until real callback measurements justify a change.
- Keep credentials out of snapshot and error payloads.
- Report transport loss as unknown state until process state and a snapshot resolve it.

## Engine process and pipes

Start the verified engine directly with Foundation `Process`, fixed arguments, and a controlled environment.
Use private inherited pipes for application-mode commands and events.
Reserve stdout for protocol frames and stderr for sanitized diagnostics.
Disable legacy control sockets for application mode.

Read both output streams continuously and enforce limits before a missing newline can fill memory.
Handle partial writes, partial reads, EOF, malformed UTF-8, broken pipes, and process exit.
Close unused pipe ends so shutdown and EOF are observable.
Keep decoding and blocking waits away from the main actor.
Use bounded buffering and preserve terminal state events when diagnostic traffic is heavy.

Maintain one process owner and one active connection.
Store child identity with the session; do not signal unrelated processes by name.
Request cooperative stop first, wait for its bounded cleanup period, and then escalate only for the owned child.
Use the recovery journal after forced termination.

## Failure handling

After XPC reconnection, negotiate versions and obtain a snapshot before enabling new session commands.
Reject late callbacks and events for older session IDs.
If the helper restarts, reconcile recorded child and network state before starting another engine.
Do not infer network restoration from child exit alone.

Follow [network restoration rules](vpn-and-networking.md) and [live helper validation](validation-and-workflow.md).
