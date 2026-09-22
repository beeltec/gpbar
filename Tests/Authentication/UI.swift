import AppKit

@main struct AuthenticationUI {
    @MainActor static var retained: AuthenticationCoordinator?
    enum Failure: Error { case check(String) }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try run()
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

    @MainActor static func run() throws {
        let preferences = ConnectionPreferences()
        let coordinator = AuthenticationCoordinator()
        let session = UUID().uuidString
        let password = EngineEvent(type: .credentialsRequired, challengeID: "password-challenge",
            message: "Local fixture. Use fixture-user and fixture-password.", server: "https://portal.example",
            usernameLabel: "Account", passwordLabel: "Password")
        let otp = EngineEvent(type: .otpRequired, challengeID: "otp-challenge",
            message: "Local fixture. Enter 123456.", server: "https://gateway.example")
        var credentials = 0, codes = 0, cancellations = 0
        coordinator.onCredentials = { receivedSession, challenge, username, secret in
            if receivedSession == session && challenge == password.challengeID
                && username == "fixture-user" && secret == "fixture-password" { credentials += 1 }
        }
        coordinator.onOTP = { receivedSession, challenge, code in
            if receivedSession == session && challenge == otp.challengeID && code == "123456" { codes += 1 }
        }
        coordinator.onCancel = { cancellations += 1 }
        coordinator.begin(sessionID: session, event: password, preferences: preferences)
        try expect(coordinator.isCredentials && coordinator.webView == nil, "native credential form")
        try expect(coordinator.hostname == "portal.example" && coordinator.usernameLabel == "Account", "endpoint and server labels")
        coordinator.submitCredentials()
        try expect(!coordinator.submitted && credentials == 0, "empty credentials rejected")
        coordinator.username = "fixture-user"
        coordinator.password = "fixture-password"
        coordinator.submitCredentials()
        coordinator.submitCredentials()
        try expect(credentials == 1 && coordinator.password.isEmpty && coordinator.username.isEmpty, "single submission clears credentials")
        coordinator.begin(sessionID: session, event: otp, preferences: preferences)
        try expect(coordinator.isOTP && !coordinator.isCredentials && coordinator.hostname == "gateway.example", "independent gateway MFA")
        coordinator.complete(challengeID: password.challengeID)
        coordinator.otp = "123456"
        coordinator.submitOTP()
        coordinator.submitOTP()
        try expect(codes == 1 && coordinator.otp.isEmpty, "stale completion ignored and code cleared")
        coordinator.complete(challengeID: otp.challengeID)
        coordinator.otp = "123456"
        coordinator.submitOTP()
        try expect(codes == 1, "late OTP ignored")
        coordinator.begin(sessionID: session, event: password, preferences: preferences)
        coordinator.username = "fixture-user"
        coordinator.password = "fixture-password"
        coordinator.cancel()
        coordinator.submitCredentials()
        try expect(credentials == 1 && cancellations == 1 && coordinator.password.isEmpty, "cancel clears credentials and disables submission")
        print("PASS: native password and MFA controls, endpoint labels, stale completion, duplicate submission, secret clearing, and cancellation")
        if CommandLine.arguments.contains("--interactive") {
            coordinator.onCredentials = { _, challenge, username, secret in
                guard challenge == password.challengeID && username == "fixture-user" && secret == "fixture-password" else {
                    print("FAIL: use the displayed synthetic credentials")
                    exit(1)
                }
                coordinator.begin(sessionID: session, event: otp, preferences: preferences)
            }
            coordinator.onOTP = { _, challenge, code in
                guard challenge == otp.challengeID && code == "123456" else { exit(1) }
                coordinator.complete(challengeID: challenge)
                print("PASS: interactive password and MFA submission")
                NSApp.terminate(nil)
            }
            coordinator.onCancel = {
                print("PASS: interactive cancellation")
                NSApp.terminate(nil)
            }
            retained = coordinator
            coordinator.begin(sessionID: session, event: password, preferences: preferences)
            print("Interactive password fixture ready")
        }
    }
}
