# Interface direction

Use native SwiftUI controls on macOS 26.
The audience needs one work VPN connection and a clear next action.
The interface should show confirmed connection state and make sign-in easy to recover.

## References

The user requested modern web references instead of the official GlobalProtect interface.
Its running application was checked only for an existing connection.

- [Raycast compact mode](https://www.raycast.com/blog/launch-week-summary#compact-mode): focused content and a quiet action row.
- [Raycast menu bar](https://www.raycast.com/uploads/launch-week/menu-bar.png): compact spacing and clear text hierarchy.
- [Little Arc](https://resources.arc.net/hc/en-us/articles/19235387524503-Little-Arc-Quick-Lookups-Instant-Triaging): a separate, focused browser window.

Use these references for hierarchy and restraint, without copying their colors or branding.

## Tokens

| Role | Choice |
| --- | --- |
| Display | SF Rounded, semibold, 20–22 points. |
| Body | SF Pro, native callout and body sizes. |
| Technical values | SF Mono, 11–12 points. |
| Accent | Route blue, `#2864DC`; dark appearance, `#81AAFF`. |
| Connected | Teal, `#087F72`; dark appearance, `#69D3C1`. |
| Attention | Amber, `#A86200`; dark appearance, `#F0BD67`. |
| Failure | Red, `#B93845`; dark appearance, `#FF929C`. |
| Text and surfaces | Native semantic colors and materials. |
| Spacing | 4, 8, 12, 16, 24 points. |

## Signature

Use `This Mac — Gateway` as a small connection instrument.
A broken line and an explicit state label show disconnection.
The final connection state must drive the line, symbols, text, and primary action together.
Avoid shields, promotional claims, traffic graphs, and decorative dashboard tiles.

```text
Connection name                      Settings

       This Mac - - - - - Gateway
                  OFFLINE

Disconnected
Connection guidance

                Connect

Edit connection…                       Quit
```

The design review retained the plan's connection path instead of adding a generic status card.
Use the compact panel for the next action and a separate window for configuration.
Keep helper implementation details in diagnostics, except permission guidance that users need.

Live visual and accessibility findings belong in `manual-validation.md`.
