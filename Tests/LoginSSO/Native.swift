import SwiftUI

@main struct LoginSSONativeTests: App {
    var body: some Scene {
        WindowGroup("GPBar login SSO fixture") { Fixture() }
    }
}

private struct Fixture: View {
    @State private var state = LoginSSOState(installed: false, portal: nil)
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("Synthetic settings check")
                Text("Uses GPBar’s actual SSO controls. Buttons change fixture memory only. No login rules or credentials are changed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Portal: https://portal.example").textSelection(.enabled)
            }
            LoginSSOSettings(state: state, isBusy: false, message: message) { enabled in
                state = LoginSSOState(installed: enabled, portal: enabled ? "https://portal.example" : nil)
                message = enabled ? "Synthetic enable received after confirmation." : "Synthetic disable received."
                print(enabled ? "PASS: explicit enable confirmation" : "PASS: disable callback")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 480)
    }
}
