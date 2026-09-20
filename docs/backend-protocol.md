# Application protocol

Protocol version: 1. Transport: authenticated XPC, then private inherited pipes.

The application and helper require matching Apple signing teams and exact code identifiers.
The helper accepts the active console user and retains that user's session ownership.
Only one session runs at a time. User switching or logout requests cancellation.
Events go only to an observer belonging to the session owner.
Inspection returns an active session ID only to its owner; other users receive a busy indication.
It also reports leftover session directories that require recovery before another connection starts.

## Commands

XPC uses bounded `Data` messages containing JSON.
The helper starts the bundled engine with the fixed argument `app-session`.
Engine stdin and stdout contain newline-delimited JSON. Stderr is drained and discarded.

```json
{"protocol_version":1,"session_id":"UUID","command_id":"UUID","command":{"type":"start","portal":"https://vpn.example.com","reconnect":true}}
```

| Command | Fields |
| --- | --- |
| `start` | HTTPS portal origin; reconnect boolean. |
| `submit_callback` | Current challenge ID; callback string. |
| `submit_otp` | Current challenge ID; verification code. |
| `cancel`, `disconnect` | No additional fields. |
| `get_snapshot` | No additional fields. |
| `recover_network` | Helper-only operation; requires no active process. Never forwarded to the engine. |

The helper acknowledges acceptance separately from completion.
Start acceptance means the owned process was launched, not that authentication or networking succeeded.
Cancellation is cooperative, followed by termination after ten seconds and forced termination three seconds later.
Recovery runs after the child exits and its output drains.
The helper publishes the final stopped event after recovery completes.

Frames are limited to 256 KiB. UTF-8, versions, identifiers, command names, and challenge ownership are checked before use.
Engine commands reject unknown fields. Swift decoders ignore unknown fields within version 1.
The engine rejects duplicate command identifiers and limits each session to 4,096 commands.
Callbacks are single-use. OTP values are limited to 1,024 bytes.

## Events

```json
{"protocol_version":1,"session_id":"UUID","sequence":2,"event":{"type":"phase_changed","phase":"preparing","attempt":0}}
```

`ready` precedes start and has an empty session ID.
The helper defers snapshot requests until Start has been queued after Ready.
Other events are `phase_changed`, `authentication_required`, `authentication_completed`, `otp_required`, `snapshot`, `failure`, and `stopped`.
Sequence numbers increase within a session. Old session events are ignored.
The helper retains the latest state, pending challenge, and terminal result for reconnection.

Snapshots contain phase, portal, optional gateway/account/interface/IPv4, start time in Unix seconds, and retry count.
They never contain authentication material.
`stopped.cleanup` reports `restored` or `unverified`. Process exit alone never proves restoration.

Authentication challenges contain a random identifier and a random-path loopback launch URL.
The launch server accepts only an exact GET path and Host header. It never accepts callback submissions.
Callback and OTP values travel through XPC and inherited pipes.
The HIP subprocess receives length-prefixed fields through another private pipe, not arguments or environment variables.

## Retry ownership

The engine owns retry policy: up to ten tunnel attempts and two reauthentication attempts.
Application mode disables OpenConnect's separate internal reconnect loop.
Each new tunnel attempt must pass the network worker's verification before publishing Connected.
Reauthentication uses the same browser and OTP command path as initial authentication.
The UI observes network changes and requests fresh state; it does not start competing retry loops.
