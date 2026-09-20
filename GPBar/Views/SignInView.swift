import SwiftUI
import WebKit

struct SignInView: View {
    @Bindable var coordinator: AuthenticationCoordinator
    @FocusState private var focusedField: Field?
    private enum Field { case username, password, otp }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.isOTP ? "Verification code" : coordinator.isCredentials ? "Sign in to your VPN" : "Finish signing in")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    if !coordinator.hostname.isEmpty {
                        Label(coordinator.hostname, systemImage: "globe")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") { coordinator.cancel() }
            }
            Text(coordinator.message).font(.callout).foregroundStyle(.secondary)
            if let error = coordinator.error {
                Text(error).foregroundStyle(Color("Failure")).font(.callout).textSelection(.enabled)
            }
            if coordinator.callbackHandlerRequired {
                Button("Use GPBar for sign-in links") { coordinator.useCallbackHandler() }
            }
            if coordinator.isCredentials {
                Form {
                    TextField(coordinator.usernameLabel, text: $coordinator.username)
                        .textContentType(.username).focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                    SecureField(coordinator.passwordLabel, text: $coordinator.password)
                        .textContentType(.password).focused($focusedField, equals: .password)
                        .onSubmit { coordinator.submitCredentials() }
                }
                .disabled(coordinator.submitted)
                Button("Sign in") { coordinator.submitCredentials() }
                    .keyboardShortcut(.defaultAction).disabled(coordinator.submitted)
            } else if coordinator.isOTP {
                SecureField("Verification code", text: $coordinator.otp)
                    .focused($focusedField, equals: .otp)
                    .onSubmit { coordinator.submitOTP() }.disabled(coordinator.submitted)
                Button("Continue") { coordinator.submitOTP() }.disabled(coordinator.submitted)
            } else if coordinator.isEmbedded, let webView = coordinator.webView {
                SignInWebView(webView: webView).frame(minWidth: 460, minHeight: 380)
            } else {
                Button("Reopen sign-in page") { coordinator.openExternal() }.disabled(coordinator.submitted)
                Spacer()
            }
            if !coordinator.isOTP && !coordinator.isCredentials {
                DisclosureGroup("Troubleshooting") {
                    if coordinator.isEmbedded {
                        Button("Start again in the default browser") { coordinator.onRetryExternally?() }
                            .disabled(coordinator.submitted)
                    }
                    HStack {
                        SecureField("Paste a sign-in callback", text: $coordinator.pastedCallback)
                            .onSubmit { coordinator.submitCallback() }
                        Button("Submit callback") { coordinator.submitCallback() }
                    }
                    .disabled(coordinator.submitted)
                    .padding(.top, 8)
                }
                .font(.caption)
            }
        }
        .padding(20)
        .onAppear { focusedField = coordinator.isCredentials ? .username : coordinator.isOTP ? .otp : nil }
    }
}

private struct SignInWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
