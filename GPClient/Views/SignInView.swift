import SwiftUI
import WebKit

struct SignInView: View {
    @Bindable var coordinator: AuthenticationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.isOTP ? "Verification code" : "Finish signing in")
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
                Button("Use GPClient for sign-in links") { coordinator.useCallbackHandler() }
            }
            if coordinator.isOTP {
                SecureField("Verification code", text: $coordinator.otp)
                    .onSubmit { coordinator.submitOTP() }.disabled(coordinator.submitted)
                Button("Continue") { coordinator.submitOTP() }.disabled(coordinator.submitted)
            } else if coordinator.isEmbedded, let webView = coordinator.webView {
                SignInWebView(webView: webView).frame(minWidth: 460, minHeight: 380)
            } else {
                Button("Reopen sign-in page") { coordinator.openExternal() }.disabled(coordinator.submitted)
                Spacer()
            }
            if !coordinator.isOTP {
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
    }
}

private struct SignInWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
