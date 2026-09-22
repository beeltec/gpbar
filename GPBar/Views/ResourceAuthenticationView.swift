import SwiftUI
import WebKit

struct ResourceAuthenticationView: View {
    @Bindable var coordinator: ResourceAuthenticationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Additional sign-in required").font(.title2)
            if let request = coordinator.request {
                Text(request.message).fixedSize(horizontal: false, vertical: true)
                Text(coordinator.hostname).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                if let error = coordinator.error { Text(error).foregroundStyle(.red) }
                if let webView = coordinator.webView {
                    ResourceWebView(webView: webView)
                } else if coordinator.opened {
                    Text("Finish signing in in your browser. Close its tab when you are done.")
                    Spacer()
                } else {
                    Text("Your VPN stays connected. Sign in only if you just tried to open a protected resource.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open sign-in") { coordinator.openSignIn() }.buttonStyle(.borderedProminent)
                }
                Text("After signing in, retry the resource. This window closes after two minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(coordinator.opened ? "Close" : "Dismiss") { coordinator.finish() }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 340)
    }
}

private struct ResourceWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
