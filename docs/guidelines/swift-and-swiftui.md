# Swift, SwiftUI, and AppKit guidelines

Research date: 2026-09-20. Scope: native application code and shared Swift models.

## API and type design

Use names that explain behavior at the call site.
Prefer clear argument labels and established Swift naming conventions over abbreviations.
Use value types for settings, transport messages, and snapshots.
Use reference types where identity or owned lifetime matters.
These choices follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).

Project rules:

- Represent connection phases with an enum and associated values instead of unrelated Boolean flags.
- Keep session IDs, challenge IDs, and command IDs distinct in the model.
- Prefer immutable properties unless the owner needs to change them.
- Keep access control narrow; expose only operations needed across module or target boundaries.
- Avoid force unwraps and `try!` for user input, I/O, XPC replies, browser events, and backend output.
- Use concrete types instead of untyped dictionaries. Do not erase type information merely to avoid modeling a message.
- Add protocols only where they define an actual boundary or multiple required implementations.
- Document non-obvious ownership and safety contracts. Do not add comments to every declaration.

## Concurrency and cancellation

Use explicit actor isolation for mutable state.
Use a `@MainActor` connection model for UI-visible state and keep expensive work outside that actor.
Pass immutable snapshots across isolation boundaries.
Adopt the supported Swift 6 language mode and resolve concurrency diagnostics during the initial compatibility phase.
For legacy modules, complete concurrency checking can support staged adoption. [Swift concurrency migration](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/)

- Do not assume that adding `async` moves work away from the main actor.
- Check the target's language mode and default-isolation settings when choosing an execution context.
- Keep process waits, blocking reads, XML parsing, and large JSON decoding away from UI execution.
- Do not use detached tasks or `@unchecked Sendable` merely to suppress a compiler error.
- Recheck the session ID after an `await`; another operation may have changed state during suspension.
- Store handles for tasks whose lifetime exceeds a view update. Cancel and release them when their owner ends.
- Make cancellation reach the helper and engine; cancelling a Swift task alone does not stop a VPN session.
- Resume a checked continuation exactly once, including error, timeout, invalidation, and cancellation paths.
- Prefer explicit isolation declarations over scattered main-queue dispatch calls.

Swift cancellation is cooperative, and callback wrappers need explicit completion discipline. [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), [Callback migration](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/)

## Observation and view ownership

Use `@Observable` for the shared connection model on the macOS 26 baseline.
Own the model at application scope using `@State`, then pass it through the environment or explicit parameters.
Use `@Bindable` only where a view needs writable bindings to an observable model.
Keep local presentation state in the view that owns it.
Observation updates views according to the properties they read. [Managing model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)

- Keep `body` free of connection commands, preference writes, and process creation.
- Start side effects from explicit actions or lifecycle tasks with clear ownership.
- Do not recreate the connection controller when the menu bar panel opens.
- Keep view code focused on presentation. Put address validation and session transitions in their owning modules.
- Render a fresh snapshot after reconnecting to the helper; do not infer disconnection from a transport error.
- Update the elapsed display locally rather than repeatedly requesting backend status.

## Menu bar and AppKit boundaries

Use `MenuBarExtra` with window style and `LSUIElement` for the intended menu bar application.
Keep login and settings in separate windows with shared application state.
Apple notes that removing a menu bar extra can terminate a menu-bar-only application. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)

- Closing the panel must not cancel the VPN.
- Distinguish closing a login window from successful programmatic dismissal.
- Route application termination through the helper's disconnect policy where termination allows it.
- Use AppKit for activation, application URL delivery, and browser opening when needed.
- Avoid private API, view-tree introspection, or window-order assumptions.
- Keep AppKit delegates and WebKit coordinators alive for the operation they serve.

## Native design and accessibility

Use the visual direction in the plan with native controls, semantic colors, system typography, and template menu bar images.
Always pair connection color or motion with a text label or distinct symbol.
Support keyboard focus, VoiceOver, increased contrast, reduced motion, and reduced transparency.
Inspect the running interface using Accessibility Inspector. [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)

Use String Catalogs for user-facing text as the application is built.
Keep technical hostnames selectable and allow long addresses to wrap.
Avoid hardcoded content heights that clip errors or larger text.
Do not announce each timer tick to VoiceOver.

Before completing UI work, follow [the live validation guide](validation-and-workflow.md).
