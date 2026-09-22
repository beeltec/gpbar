import AppKit
import Foundation

@main struct ResourceMFATests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run(interactive: CommandLine.arguments.contains("--interactive"))
                if !CommandLine.arguments.contains("--interactive") { app.terminate(nil) }
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    enum Failure: Error { case check(String) }
    static func expect(_ value: Bool, _ label: String) throws {
        if !value { throw Failure.check(label) }
    }

    @MainActor static func run(interactive: Bool) async throws {
        let session = UUID().uuidString
        let now = Date()
        let url = "https://example.com/php/uid.php?vsys=1&rule=0"
        let event = EngineEvent(type: .resourceAuthenticationRequired,
            expiresAtUnix: UInt64(now.timeIntervalSince1970) + 120,
            challengeID: String(repeating: "a", count: 48), launchURL: url,
            message: "Local fixture: a protected resource needs sign-in.")
        let decoded = try JSONDecoder().decode(EngineEvent.self, from: JSONEncoder().encode(event))
        guard let request = ResourceAuthenticationRequest(sessionID: session, event: decoded, now: now) else {
            throw Failure.check("valid request")
        }
        try expect(ResourceAuthenticationRequest(sessionID: "old-session", event: event) == nil, "invalid session")
        for expiry in [UInt64(0), UInt64(now.timeIntervalSince1970) - 1, UInt64(now.timeIntervalSince1970) + 126] {
            var invalid = event
            invalid.expiresAtUnix = expiry
            try expect(ResourceAuthenticationRequest(sessionID: session, event: invalid, now: now) == nil, "expiry bounds")
        }
        for value in [url.replacingOccurrences(of: "https:", with: "http:"),
            url.replacingOccurrences(of: "example.com", with: "user:secret@example.com"),
            url + "#fragment", url + "&", url + "&rule=1", url + "&redirect=https://evil.example",
            url.replacingOccurrences(of: "uid.php", with: "other.php"), url + "\n"] {
            var invalid = event
            invalid.launchURL = value
            try expect(ResourceAuthenticationRequest(sessionID: session, event: invalid, now: now) == nil, "unsafe target")
        }
        var invalid = event
        invalid.message = "safe\u{202E}\u{200E}\u{200F}"
        try expect(ResourceAuthenticationRequest(sessionID: session, event: invalid)?.message == "safe", "direction controls sanitized")
        invalid = event
        invalid.challengeID = "old-challenge"
        try expect(ResourceAuthenticationRequest(sessionID: session, event: invalid) == nil, "invalid challenge")
        let coordinator = ResourceAuthenticationCoordinator()
        coordinator.begin(request, browser: .inApp, browserID: "")
        try expect(coordinator.webView == nil && !coordinator.opened, "no automatic navigation")
        coordinator.openSignIn()
        try expect(coordinator.webView != nil && coordinator.opened, "explicit browser launch")
        try expect(coordinator.webView?.configuration.websiteDataStore.isPersistent == false, "isolated browser storage")
        coordinator.finish()
        try expect(coordinator.request == nil && coordinator.webView == nil, "session cleanup")
        coordinator.openSignIn()
        try expect(coordinator.webView == nil, "stale action rejected")
        var short = event
        short.expiresAtUnix = UInt64(Date().timeIntervalSince1970) + 1
        guard let expiring = ResourceAuthenticationRequest(sessionID: session, event: short) else { throw Failure.check("short fixture") }
        coordinator.begin(expiring, browser: .inApp, browserID: "")
        try await Task.sleep(for: .seconds(1.2))
        try expect(coordinator.request == nil, "expiry closes window")
        print("PASS: resource MFA Swift validation, browser isolation, stale actions, cleanup, and expiry")
        if interactive {
            let retained = ResourceAuthenticationCoordinator()
            retained.begin(request, browser: .inApp, browserID: "")
            liveCoordinator = retained
            print("Interactive fixture ready. Open sign-in loads example.com, which has no MFA provider.")
        }
    }

    @MainActor static var liveCoordinator: ResourceAuthenticationCoordinator?
}
