import AppKit
import WebKit

@main struct CloudIdentityTests {
    @MainActor static var retained: AuthenticationCoordinator?
    enum Failure: Error { case check(String) }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                if !CommandLine.arguments.contains("--interactive") { app.terminate(nil) }
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    static func expect(_ value: Bool, _ label: String) throws {
        if !value { throw Failure.check(label) }
    }

    @MainActor static func waitFor(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.check(label)
    }

    @MainActor static func run() async throws {
        let preferences = ConnectionPreferences()
        preferences.authenticationMethod = .cloudIdentity
        preferences.browser = .specific
        preferences.browserID = "fixture.browser"
        try expect(ConnectionPreferences().authenticationMethod == .cloudIdentity, "authentication choice restored")
        let coordinator = AuthenticationCoordinator()
        var received: [(String, String, String)] = []
        var cancellations = 0
        coordinator.onCallback = { received.append(($0, $1, $2)) }
        coordinator.onCancel = { cancellations += 1 }
        let session = UUID().uuidString
        var event = EngineEvent(type: .authenticationRequired, challengeID: String(repeating: "a", count: 48),
            launchURL: "http://127.0.0.1:1/" + String(repeating: "b", count: 48), cloudIdentity: true)
        let decoded = try JSONDecoder().decode(EngineEvent.self, from: JSONEncoder().encode(event))
        try expect(decoded.cloudIdentity == true, "CAS IPC round trip")
        let callback = "globalprotectcallback:cas-as=1&un=alice%40example.com&token=fixture-token"
        coordinator.submitCallback(callback)
        try expect(received.isEmpty, "cold callback ignored")
        coordinator.begin(sessionID: session, event: event, preferences: preferences, browserOverride: .inApp)
        try expect(preferences.browser == .specific && preferences.browserID == "fixture.browser", "browser preference preserved")
        guard let webView = coordinator.webView else { throw Failure.check("embedded browser exists") }
        try expect(!webView.configuration.websiteDataStore.isPersistent, "isolated browser")
        webView.stopLoading()
        webView.loadHTMLString("<html><!-- <cas-as>1</cas-as><un>alice@example.com</un><token>fixture-token</token> --><body>Fixture completion</body></html>", baseURL: URL(string: "https://cie.example"))
        try await waitFor("CAS completion extracted") { received.count == 1 }
        try expect(received[0].0 == session && received[0].1 == event.challengeID, "session and challenge retained")
        try expect(received[0].2 == callback, "only CAS fields extracted")
        coordinator.submitCallback(callback)
        try expect(received.count == 1, "duplicate ignored")
        coordinator.complete(challengeID: "stale")
        try expect(coordinator.webView != nil, "wrong completion ignored")
        coordinator.complete(challengeID: event.challengeID)
        try expect(coordinator.webView == nil && cancellations == 0, "success closes without cancellation")
        coordinator.submitCallback(callback)
        try expect(received.count == 1, "late callback ignored")

        event.challengeID = String(repeating: "c", count: 48)
        coordinator.begin(sessionID: session, event: event, preferences: preferences, browserOverride: .inApp)
        guard let second = coordinator.webView else { throw Failure.check("new browser exists") }
        second.stopLoading()
        second.loadHTMLString("<html><body><cas-as>1</cas-as><un>alice</un><token>one</token><token>two</token></body></html>", baseURL: URL(string: "https://cie.example"))
        try await waitFor("malformed fixture loaded") { !second.isLoading }
        try await Task.sleep(for: .milliseconds(200))
        try expect(received.count == 1, "duplicate completion fields rejected")
        coordinator.cancel()
        try expect(coordinator.webView == nil && cancellations == 1, "cancel closes window")
        coordinator.webView(webView, didFinish: nil)
        try expect(received.count == 1, "old browser cannot complete new session")

        event.challengeID = String(repeating: "d", count: 48)
        event.cloudIdentity = false
        coordinator.begin(sessionID: session, event: event, preferences: preferences, browserOverride: .inApp)
        guard let classic = coordinator.webView else { throw Failure.check("SAML browser exists") }
        classic.stopLoading()
        classic.loadHTMLString("<html><body><cas-as>1</cas-as><un>alice</un><token>fixture</token></body></html>", baseURL: URL(string: "https://cie.example"))
        try await waitFor("classic fixture loaded") { !classic.isLoading }
        try await Task.sleep(for: .milliseconds(200))
        try expect(received.count == 1, "SAML does not extract CAS pages")
        try await classic.evaluateJavaScript("location.href = 'globalprotectcallback:cas-as=1&un=alice%40example.com&token=fixture-token'")
        try await waitFor("WebKit callback intercepted") { received.count == 2 }
        coordinator.finish()
        print("PASS: native CAS completion, browser isolation, preferences, IPC, callback ownership, duplicate rejection, cancellation, and cleanup")

        if CommandLine.arguments.contains("--interactive") {
            event.challengeID = String(repeating: "e", count: 48)
            event.cloudIdentity = true
            coordinator.begin(sessionID: session, event: event, preferences: preferences, browserOverride: .inApp)
            coordinator.webView?.stopLoading()
            coordinator.webView?.loadHTMLString("<html><body style='font:18px system-ui;padding:32px'><h1>Cloud Identity Engine fixture</h1><p>This page uses synthetic credentials.</p><p>No VPN server or identity provider is connected.</p><a href='\(callback)'>Finish synthetic sign-in</a></body></html>", baseURL: URL(string: "https://cie.example"))
            coordinator.onCallback = { _, challenge, _ in
                coordinator.complete(challengeID: challenge)
                print("PASS: interactive callback and owned-window cleanup")
                NSApp.terminate(nil)
            }
            coordinator.onCancel = {
                print("PASS: interactive cancellation and owned-window cleanup")
                NSApp.terminate(nil)
            }
            retained = coordinator
            print("Interactive fixture ready")
        }
    }
}
